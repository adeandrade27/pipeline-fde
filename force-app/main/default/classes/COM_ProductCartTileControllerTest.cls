@IsTest
private class COM_ProductCartTileControllerTest {
    @IsTest
    static void testAddToCart_stubCompletes() {
        Test.startTest();
        COM_ProductCartTileController.addToCart('01t000000000000AAA');
        Test.stopTest();
        Assert.isTrue(true, 'Stub should complete without error');
    }

    @IsTest
    static void testAddToCart_nullId() {
        Test.startTest();
        COM_ProductCartTileController.addToCart(null);
        Test.stopTest();
        Assert.isTrue(true, 'Stub accepts null product id');
    }
}