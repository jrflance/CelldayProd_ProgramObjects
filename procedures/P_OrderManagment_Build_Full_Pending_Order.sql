--liquibase formatted sql

--changeset gaberalawi:f1bcbc1c stripComments:false runOnChange:true

-- =============================================
--    Author   : Gaber Alawi
--        Date : 1/15/2024
-- Description : build order header and order item for pending order
-- =============================================
CREATE OR ALTER PROC [OrderManagment].[P_OrderManagment_Build_Full_Pending_Order]
    (
        @AccountID INT,
        @Datefrom DATETIME,
        @OrdertypeID INT,
        @OrderRefNumber INT,
        @ProductID INT,
        @Amount DECIMAL(9, 2),
        @DiscountAmount DECIMAL(5, 2),
        @NewOrderID INT OUTPUT,
        @NewOrderNumber INT OUTPUT
    )
AS
BEGIN
    DECLARE
        @CustomerID INT,
        @Shipto INT,
        @UserID INT,
        @DateDue DATETIME,
        @CreditTermID INT,
        @DiscountClassID INT,
        @DateFilled DATETIME,
        @DateOrdered DATETIME,
        @ProductName VARCHAR(100)
    BEGIN TRY
        BEGIN TRANSACTION [Tran1]

        SELECT
            @CreditTermID = CreditTerms_ID,
            @DiscountClassID = DiscountClass_ID,
            @CustomerID = Customer_ID,
            @Shipto = ShipTo,
            @UserID = User_ID
        FROM Account
        WHERE Account_ID = @AccountID

        EXEC OrderManagment.P_OrderManagment_CalculateDueDate
            @AccountID = @AccountID, -- int
            @Date = @Datefrom, -- datetime
            @DueDate = @DateDue OUTPUT-- date


        SET @DateFilled = GETDATE()
        SET @DateOrdered = GETDATE()

        EXEC OrderManagment.P_OrderManagment_Build_Order_Header
            @MID = @AccountID, -- int
            @CustomerID = @CustomerID, -- int
            @ShipID = @Shipto, -- int
            @UID = @UserID, -- nvarchar(10)
            @UserIP = N'127.0.0.1', -- nvarchar(20)
            @Datedue = @DateDue, -- datetime
            @Server = '192.168.151.9', -- nvarchar(50)
            @Process = 0, -- bit
            @Filled = 0, -- bit
            @Void = 0, -- bit
            @Paid = 0, -- bit
            @DateOrdered = @DateOrdered, -- datetime
            @DateFilled = @DateFilled, -- datetime
            @OrderTypeID = @OrdertypeID, -- int
            @CreditTerms = @CreditTermID, -- int
            @DiscountClass = @DiscountClassID, -- int
            @Reason = '', -- ntext
            @AuthNumber = @OrderRefNumber, -- nvarchar(50)
            @Order_no = @NewOrderNumber OUTPUT-- int


        SELECT @ProductName = Name
        FROM dbo.Products
        WHERE Product_ID = @ProductID

        INSERT INTO dbo.Orders
        (
            Order_No,
            Product_ID,
            Addons,
            Price,
            Quantity,
            SKU,
            DiscAmount,
            Name,
            E911Tax,
            Fee,
            ParentItemID
        )
        VALUES (
            @NewOrderNumber, -- Order_No - int
            @ProductID, -- Product_ID - int
            '', -- Addons - ntext
            @Amount, -- Price - decimal
            1, -- Quantity - int
            N'', -- SKU - nvarchar(100)
            @DiscountAmount, -- DiscAmount - decimal
            @ProductName, -- Name - nvarchar(255)
            0.0, -- E911Tax - float
            0, -- Fee - decimal
            0  -- ParentItemID - int
        )

        SELECT @NewOrderID = SCOPE_IDENTITY()

        UPDATE dbo.Order_No
        SET OrderTotal = @Amount
        WHERE Order_No = @NewOrderNumber

        COMMIT TRANSACTION [Tran1]
    END TRY
    BEGIN CATCH
        THROW
    END CATCH
END
GO
